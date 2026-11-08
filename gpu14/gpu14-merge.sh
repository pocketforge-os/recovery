#!/usr/bin/env bash
# gpu-14 2026-10-13: merge wrapper. Runs provenance guards that review does not cover, then pf-pr-merge.sh.
# Guard 1 (vendor): launcher#159 hand-edited vendor/pf-framehost-wayland (+247/-46 and .cargo-checksum.json) and I
# merged it; launcher main stopped being derivable from any runtime commit (second witness after launcher#140,
# 2026-09-22). A PR touching any vendor/ tree is refused unless --vendor-ok names the source PR or commit that
# already contains the same change (the vendored copy must be a re-vendor of merged source, never an edit).
# usage: gpu14-merge.sh [--vendor-ok '<source repo>@<sha or #pr> reason'] <owner/repo#n> [pf-pr-merge.sh args, e.g. --allow-red NAME]
# --allow-red only for a check that is skipped or disabled BY DESIGN (cite the workflow line in the bead), never to pass a real failure.
set -uo pipefail
vok=
[ "${1:-}" = --vendor-ok ] && { vok=${2:?--vendor-ok needs a source reference}; shift 2; }
ref=${1:?usage: gpu14-merge.sh [--vendor-ok '<source> reason'] <owner/repo#n>}
repo=${ref%#*}; n=${ref##*#}
[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $n =~ ^[0-9]+$ ]] || { echo "GPU14_MERGE_REFUSED reason=bad_ref ref=$ref"; exit 2; }
files=$(gh pr view "$n" -R "$repo" --json files --jq '.files[].path') || { echo "GPU14_MERGE_REFUSED reason=files_unreadable ref=$ref"; exit 2; }
vend=$(printf '%s\n' "$files" | grep -E '(^|/)vendor/' || true)
# gpu-14 2026-10-18 (runtime#157): a new workspace crate changes Cargo.lock, so cargo-vendor rewrites only the
# lock stamp vendor/.pocketforge-vendor-lock. That is not a vendored-code edit. Accept it without --vendor-ok only when,
# at the PR head: the stamp is the ONLY vendor/ file; its cargo_lock_sha256 equals sha256(Cargo.lock beside vendor/);
# vendored_packages is unchanged from base; and the Cargo.lock diff adds no package with a source = line.
if [ -z "$vok" ] && [ -n "$vend" ] && [ "$(printf '%s\n' "$vend" | grep -c .)" = 1 ] && [[ $vend =~ ^(.*/)?vendor/\.pocketforge-vendor-lock$ ]]; then
  dir=${BASH_REMATCH[1]}
  meta=$(gh api "repos/$repo/pulls/$n" --jq '.head.sha+" "+.base.sha') || meta=
  head=${meta% *}; base=${meta#* }
  raw() { gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$1?ref=$2" 2>/dev/null; }
  stamp_h=$(raw "${vend}" "$head"); stamp_b=$(raw "${vend}" "$base")
  lock_sha=$(raw "${dir}Cargo.lock" "$head" | sha256sum | cut -d' ' -f1)
  want=$(printf '%s\n' "$stamp_h" | sed -n 's/^cargo_lock_sha256=//p')
  pk_h=$(printf '%s\n' "$stamp_h" | sed -n 's/^vendored_packages=//p'); pk_b=$(printf '%s\n' "$stamp_b" | sed -n 's/^vendored_packages=//p')
  added_src=$(gh api "repos/$repo/pulls/$n/files" --paginate --jq ".[]|select(.filename==\"${dir}Cargo.lock\")|.patch" | grep -cE '^\+source = ' || true)
  if [[ $head =~ ^[0-9a-f]{40}$ && -n $want && $want = "$lock_sha" && -n $pk_h && $pk_h = "$pk_b" && $added_src = 0 ]]; then
    vok="$repo@$head lock-stamp only (auto-verified): cargo_lock_sha256=${want:0:12} matches Cargo.lock, vendored_packages=$pk_h unchanged, no registry/git package added"
  else
    echo "GPU14_MERGE lockstamp_check=FAIL want=${want:0:12} lock=${lock_sha:0:12} pkgs=$pk_b->$pk_h added_src=$added_src"
  fi
fi
if [ -n "$vend" ]; then
  cnt=$(printf '%s\n' "$vend" | grep -c .)
  if [ -z "$vok" ]; then
    echo "GPU14_MERGE_REFUSED reason=vendor_tree_touched ref=$ref files=$cnt first=$(printf '%s\n' "$vend" | head -3 | paste -sd, -)"
    echo "hint=vendored crates are cargo-vendor output: land the change in the source repo first, then re-vendor; rerun with --vendor-ok '<source repo>@<merged sha> reason' after verifying the vendored files equal that source"
    exit 3
  fi
  echo "GPU14_MERGE vendor_ok='$vok' files=$cnt"
fi
shift
exec pf-automation-tool pf-pr-merge.sh "$ref" "$@"
