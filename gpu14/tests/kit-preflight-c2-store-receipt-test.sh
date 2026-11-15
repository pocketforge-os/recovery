#!/usr/bin/env bash
# tsp-hqm1p.182.216: hermetic test that kit-preflight.sh C2 resolves a publish receipt from the image-publications store.
# 19 of 23 preflights ended C4 SKIP c2_receipt_unavailable because the only receipt sources were receipt-*.json beside the
# image and build*-publish dirs (last: build55, 10-29), while current images come through
# $KP_IMAGE_PUB_DIR/<sha256>/full-image-receipt.json. Match is exact on ImageSource.RawSHA256; symlinks are refused.
# The observable is the C4 line: SKIP c2_receipt_unavailable (no receipt) vs SKIP c4_plan_not_declared (receipt found).
# Faked in a private temp root; no device, runner, pf-task or network. usage: kit-preflight-c2-store-receipt-test.sh
set -uo pipefail
BIN=${KP_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
KP=$BIN/kit-preflight.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/kp-c2-store-tests.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
G=11111111111111111111111111111111; OWN=pft-aaaaaaaaaaaaaaaaaaaaaaaa
export GPU14_ROOT=$T/root PF_KIT_WINDOWS_DIR=$T/kw PF_WINDOW_RUNNER_REPO=$T/clone KP_PUBLISH_ROOT=$T/root \
  KP_RUN_HOME=$T/fake KP_IMAGE_PATH_CHECK=$T/fake KP_CHAIN=$T/fake KP_BUDGET=$T/fake \
  KP_PLAN_PREFIX=$T/plans/ KP_DENYLIST=$T/root/image-denylist.txt KP_ARTIFACT_BASE=http://127.0.0.1:9/none \
  KP_IMAGE_PUB_DIR=$T/pub
mkdir -p "$T"/{root,kw,clone,plans,pub}; echo '# deny' > "$T/root/image-denylist.txt"
printf '#!/bin/sh\nexit 2\n' > "$T/fake"; chmod +x "$T/fake"
printf 'iteration image bytes\n' > "$T/Image.img"
RAW=$(sha256sum < "$T/Image.img" | cut -c1-64); BYTES=$(stat -c %s "$T/Image.img")
OTHER=$(printf 'other' | sha256sum | cut -c1-64)
PK=$T/pkg; mkdir -p "$PK/seed-kit" "$PK/image" "$PK/series"; chmod 700 "$PK"
cp "$T/Image.img" "$PK/image/Image.img"
printf '{"ImageSource":{"RawSHA256":"%s","RawBytes":%s}}\n' "$RAW" "$BYTES" > "$PK/seed-kit/felboot-request.json"
printf '{"Generation":"%s"}\n' "$G" > "$PK/boot-open-request.json"
c4line() { "$KP" "$PK" "$G" "$OWN" 2>&1 | grep '^KIT_PREFLIGHT check=C4 '; }
expect() {  # expect <name> <substring>
  local got; got=$(c4line)
  case "$got" in *"$2"*) ok "$1" ;; *) no "$1" "${got:-no C4 line}" ;; esac
}
store() {  # store <dir> <raw>: a store entry like image-publications/sha256/<dir>/full-image-receipt.json
  mkdir -p "$T/pub/$1"
  printf '{"ImageSource":{"RawSHA256":"%s","Schema":"pocketforge.full-image/v1"},"Schema":"pocketforge.full-image-receipt/v1"}\n' "$2" > "$T/pub/$1/full-image-receipt.json"
}
# 19-of-23 shape: image local, no receipt beside it or in build*-publish, empty store.
expect no_receipt_anywhere_is_unavailable "reason=c2_receipt_unavailable"
store aaaa "$OTHER"
expect store_entry_for_other_image_not_matched "reason=c2_receipt_unavailable"
store bbbb "$RAW"
expect store_entry_for_this_image_found "reason=c4_plan_not_declared"
rm -rf "$T/pub/bbbb"; mkdir -p "$T/pub/cccc"; ln -s "$T/pub/aaaa/full-image-receipt.json" "$T/pub/cccc/full-image-receipt.json"
store dddd "$OTHER"; cp "$T/pub/dddd/full-image-receipt.json" "$T/other.json"
sed -i "s/$OTHER/$RAW/" "$T/other.json"; rm -rf "$T/pub/cccc"; mkdir -p "$T/pub/cccc"
ln -s "$T/other.json" "$T/pub/cccc/full-image-receipt.json"
expect symlinked_store_receipt_refused "reason=c2_receipt_unavailable"
rm -rf "$T/pub/cccc"
printf '{"ImageSource":{"RawSHA256":"%s"}}\n' "${RAW:0:62}00" > "$T/pub/aaaa/full-image-receipt.json"
expect near_miss_sha_not_matched "reason=c2_receipt_unavailable"
printf '{"Note":"%s","ImageSource":{"RawSHA256":"%s"}}\n' "$RAW" "$OTHER" > "$T/pub/aaaa/full-image-receipt.json"
expect sha_in_other_field_not_matched "reason=c2_receipt_unavailable"
rm -rf "$T/pub"; mkdir -p "$T/pub/eeee"; printf 'not json' > "$T/pub/eeee/full-image-receipt.json"
expect unparsable_entry_skipped "reason=c2_receipt_unavailable"
KP_IMAGE_PUB_DIR=$T/absent expect missing_store_dir_is_unavailable "reason=c2_receipt_unavailable"
# A beside-the-image receipt still wins (unchanged behaviour).
printf '{"RawSHA256":"%s"}\n' "$RAW" > "$PK/image/receipt-x.json"
expect beside_image_receipt_still_found "reason=c4_plan_not_declared"
echo "kit-preflight-c2-store-receipt-test: pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
