#!/usr/bin/env bash
# gpu-14: platform lock PR -> pr-chain (CI, Codex, threads, merge) -> owned-image build -> publish.
# usage: lock-chain.sh <platform_pr> [profile=a133-open-7x-gpu] [variant=dev]
set -uo pipefail
N=$1; P=${2:-a133-open-7x-gpu}; V=${3:-dev}
A=pocketforge-os/pocketforge-automation; R=pocketforge-os/platform
S=/tmp/claude-1000/-home-matt-mission-control/b4ca9c12-a87b-4eff-b1c9-8b84d370f0a3/scratchpad/gpu14
cd /home/matt/mission-control || exit 9
# Forcing function (2026-09-30, platform#236 -> build 36682611007 "F13 launcher pin drift"): every
# `[ "${PF_*_SHA}" = "<sha>" ]` guard in the image pinned by the PR head must name a sha present in
# the PR head's platform.lock. Checked BEFORE review/merge, so a missing co-pin never lands.
H=$(gh pr view "$N" --repo "$R" --json headRefOid --jq .headRefOid) || exit 9
gh api "repos/$R/contents/platform.lock?ref=$H" --jq .content | base64 -d > "$S/lock-$N-$H.lock" || exit 9
IMG=$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print([r["sha"] for r in d["repos"] if r["name"]=="image"][0])' "$S/lock-$N-$H.lock") || exit 9
MIR=$S/image-mirror; [ -d "$MIR" ] || git clone -q --bare --filter=blob:none https://github.com/pocketforge-os/image.git "$MIR"
git -c gc.auto=0 -C "$MIR" fetch -q origin "+refs/heads/*:refs/heads/*" 2>/dev/null; git -C "$MIR" cat-file -e "$IMG^{commit}" || git -c gc.auto=0 -C "$MIR" fetch -q origin "$IMG"
drift=0
while read -r v sha; do
  if /usr/bin/grep -q "$sha" "$S/lock-$N-$H.lock"; then echo "pin_guard $v $sha in_lock=yes"; else echo "pin_guard $v $sha in_lock=NO"; drift=1; fi
done < <(git -C "$MIR" grep -h -o -E '\[ "\$\{?PF_[A-Z0-9_]+_SHA\}?" = "[0-9a-f]{40}" \]' "$IMG" | sort -u | sed -E 's/.*(PF_[A-Z0-9_]+_SHA)\}?" = "([0-9a-f]{40}).*/\1 \2/')
[ "$drift" = 0 ] || { echo "STOP_PIN_GUARD_DRIFT image=$IMG (a guard names a sha absent from the PR head's platform.lock)"; exit 5; }
# Forcing function (2026-09-30, platform#239 -> U-Boot 24284b73 aborted initr_dm on the device, and
# platform#240 had already stacked the D-pad fix on top, so the owner's image carried an unbootable boot chain):
# A133 boot-chain pins must be device-proven (device-proven-bootchain.txt, one receipt per sha).
#  - head unproven and main unproven -> STOP_BOOTCHAIN_STACKING (bench or revert main's boot chain first);
#  - head unproven, main proven -> only with PF_BOOTCHAIN_PROBE=1: the image is benched ALONE before any other lock;
#  - head proven (including a revert) -> pass.
gh api "repos/$R/contents/platform.lock?ref=main" --jq .content | base64 -d > "$S/lock-main-for-$N.lock" || exit 9
PROVEN=/home/matt/recovery/gpu14/device-proven-bootchain.txt
bc() { python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); [print(r["name"], r["sha"]) for r in d["repos"] if r["name"] in ("u-boot-tsp-a133","tfa-tsp-a133")]' "$1"; }
unproven() { while read -r n s; do /usr/bin/grep -qE "^$n $s( |$)" "$PROVEN" || echo "$n $s"; done < <(bc "$1"); }
for f in "$S/lock-$N-$H.lock" "$S/lock-main-for-$N.lock"; do [ "$(bc "$f" | wc -l)" = 2 ] || { echo "STOP_BOOTCHAIN_UNREADABLE $f"; exit 6; }; done
HU=$(unproven "$S/lock-$N-$H.lock"); MU=$(unproven "$S/lock-main-for-$N.lock")
echo "bootchain head_unproven=[${HU//$'\n'/,}] main_unproven=[${MU//$'\n'/,}]"
if [ -n "$HU" ] && [ -n "$MU" ]; then echo "STOP_BOOTCHAIN_STACKING main already carries an unproven boot chain; bench it alone or revert it first"; exit 6; fi
if [ -n "$HU" ] && [ "${PF_BOOTCHAIN_PROBE:-0}" != 1 ]; then echo "STOP_BOOTCHAIN_UNPROVEN set PF_BOOTCHAIN_PROBE=1 only for a boot-chain probe lock whose image is benched ALONE before any other lock"; exit 6; fi
[ -z "$HU" ] || echo "BOOTCHAIN_PROBE: the built image must be device-benched alone; no other lock until device-proven-bootchain.txt gains [${HU//$'\n'/,}] or main reverts"
/home/matt/recovery/gpu14/pr-chain.sh "$R" "$N" 60 | /usr/bin/grep -E '^(chain|ci |CI_|verdict|NOT_|UNRES|merge_status|final|DRYRUN|HEAD_)'
M=$(gh pr view "$N" --repo "$R" --json state,mergeCommit --jq 'select(.state=="MERGED") | .mergeCommit.oid')
[ -n "$M" ] || { echo "STOP_NOT_MERGED"; exit 3; }
git -C /home/matt/platform pull --ff-only -q; echo "platform_head=$(git -C /home/matt/platform rev-parse HEAD) merge=$M"
gh workflow run owned-image-build.yml --repo $A -f profile=$P -f variant=$V -f platform_sha=$M; sleep 15
RID=$(gh run list --repo $A --workflow owned-image-build.yml --limit 5 --json databaseId,createdAt --jq 'sort_by(.createdAt) | last | .databaseId'); echo "build_run=$RID"
for i in $(seq 1 240); do st=$(gh run view $RID --repo $A --json status,conclusion --jq '"\(.status) \(.conclusion)"'); case "$st" in completed*) break;; esac; sleep 30; done
echo "build: $st"; case "$st" in *success*) ;; *) echo STOP_BUILD; exit 4;; esac
cd $S/pfa-pub && scripts/publish-owned-image --run $RID --artifact owned-image-$P-$V-$RID-1 > $S/publish-$RID.log 2>&1; echo "publish_rc=$?"
/usr/bin/grep -o 'platform_sha=[0-9a-f]*\|descriptor_sha256=[0-9a-f]*\|compressed_sha256=[0-9a-f]*\|raw_sha256=[0-9a-f]*\|publish_status=[A-Z]*' $S/publish-$RID.log | sort -u
