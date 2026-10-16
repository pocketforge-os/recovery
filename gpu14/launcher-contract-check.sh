#!/usr/bin/env bash
# gpu-14 forcing function (2026-09-28): before OK-ing ANY launcher/runtime vendored-crate PR,
# run the IMAGE's own fail-closed contract guard against the exact trees. It checks both src sameness
# AND reference closure (every vendored Cargo path dep, dev-deps included, resolves).
#
# Written after I OK'd launcher#143 on a blob-level "vendored crates are byte-identical" check. The
# merged launcher 2c8f8191 could not be built into any image: vendor/pf-session-authority dev-depends
# on ../pf-app-launch, which was never vendored. Memory a-passing-equality-guard-means-no-drift-not-
# correctness already described that exact trap, so a remembered rule was not enough.
#
# usage: launcher-contract-check.sh <launcher_ref> <runtime_ref> [image_ref=origin/main]
# Crate set: every crate present in BOTH launcher/vendor and runtime/crates, so newly vendored
# contract crates are covered even before the image's Dockerfile list names them.
set -euo pipefail
L_REF=${1:?launcher ref}; R_REF=${2:?runtime ref}; I_REF=${3:-origin/main}
MIR=/home/matt/wt/.mirrors
tmp=$(mktemp -d "${TMPDIR:-/tmp}/pf-lcc.XXXXXX"); trap 'rm -rf -- "$tmp"' EXIT
for r in launcher runtime image; do git -C "$MIR/$r.git" fetch -q origin 2>/dev/null || true; done
mkdir "$tmp/launcher" "$tmp/runtime"
git -C "$MIR/launcher.git" archive "$L_REF" | tar -x -C "$tmp/launcher"
git -C "$MIR/runtime.git" archive "$R_REF" | tar -x -C "$tmp/runtime"
git -C "$MIR/image.git" show "$I_REF:scripts/check-launcher-runtime-contract.sh" > "$tmp/guard.sh"
crates=()
for d in "$tmp/launcher/vendor"/*/; do
    c=$(basename "$d"); [ -d "$tmp/runtime/crates/$c" ] && crates+=("$c")
done
[ "${#crates[@]}" -gt 0 ] || { echo "launcher_contract=FAIL reason=no_shared_crates"; exit 1; }
echo "launcher_ref=$(git -C "$MIR/launcher.git" rev-parse "$L_REF") runtime_ref=$(git -C "$MIR/runtime.git" rev-parse "$R_REF") guard_from=image@$(git -C "$MIR/image.git" rev-parse --short "$I_REF")"
echo "crates=${crates[*]}"
# 2026-10-15: also run the guard over the IMAGE's own crate list (build/Dockerfile.pf call site). The
# superset above flags pf-prefsd's ../systemd/pf-prefsd.service reference, which the shipped pair
# 55acd7fc/31eaa601 fails identically: the image never checks pf-prefsd. image_list_contract is the
# production verdict; launcher_contract (superset) stays the stricter forcing function.
img_crates=$(git -C "$MIR/image.git" show "$I_REF:build/Dockerfile.pf" | awk '/^check-launcher-runtime-contract \/work\/launcher/{on=1;next} on{l=$0; sub(/\\$/,"",l); printf "%s ", l; if ($0 !~ /\\$/) exit}')
if [ -n "${img_crates// }" ]; then
    # shellcheck disable=SC2086
    if sh "$tmp/guard.sh" "$tmp/launcher" "$tmp/runtime" $img_crates > "$tmp/out_img" 2>&1; then
        echo "image_list_contract=PASS crates=$(echo $img_crates | wc -w)"
    else
        grep -E 'FATAL' "$tmp/out_img" | head -8 | sed 's/^/image_list: /'
        echo "image_list_contract=FAIL crates=$(echo $img_crates | wc -w)"
    fi
else
    echo "image_list_contract=UNKNOWN reason=call_site_not_found"
fi
if sh "$tmp/guard.sh" "$tmp/launcher" "$tmp/runtime" "${crates[@]}" > "$tmp/out" 2>&1; then
    echo "launcher_contract=PASS"
else
    grep -E 'FATAL' "$tmp/out" | head -8
    echo "launcher_contract=FAIL"
    exit 1
fi
