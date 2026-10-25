#!/usr/bin/env bash
# release-run.sh KEEP_WORKTREE / PRESERVATION / receipt read-back (tsp-mc9m.41.1030.42).
# Hermetic: temp git repos, a stub pf-task (records run.release requests, serves a configured receipt),
# stub home resolver, gh and pf-automation-tool. Never touches a live home, tree or the deployed script.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=$HERE/release-run.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

STUBS=$TMP/stubs; GPU=$TMP/gpu14; WT=$TMP/wt; PRES=$TMP/release-preserved; CALLS=$TMP/calls
mkdir -p "$STUBS" "$GPU" "$WT" "$PRES" "$CALLS"
cat > "$GPU/pf-task-run-home" <<EOF
#!/bin/sh
printf 'PFT=%s; H=%s\n' "$STUBS/pf-task" "$TMP/home"
EOF
cat > "$STUBS/pf-task" <<'EOF'
#!/usr/bin/env bash
# args: --home H --role coordinator <op> <json>
op=$5; payload=$6
state=$(cat "$CALLS/state" 2>/dev/null || echo awaiting_release)
case "$op" in
  run.status)
    python3 - "$state" <<'PY'
import json, os, sys
status = {"state": sys.argv[1], "run_id": "pft-test", "worktree": {"text": os.environ["RUN_WORKTREE"]}}
if sys.argv[1] == "released":
    status.update(json.loads(os.environ.get("STUB_RECEIPT") or "{}"))
print(json.dumps(status))
PY
    ;;
  run.result) echo '{"total":0,"results":[]}' ;;
  run.release) printf '%s\n' "$payload" > "$CALLS/release.json"; echo released > "$CALLS/state"; echo '{}' ;;
  *) echo "unexpected op $op" >&2; exit 9 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUBS/gh"
# The pf-wt double removes the named set (as the real one does) unless FAKE_RM_FAIL makes it refuse.
printf '#!/bin/sh\necho "$*" >> "%s/remove"\n[ -z "${FAKE_RM_FAIL:-}" ] || { echo "pf-wt: refuse=x reason=ownership_unproven" >&2; exit 1; }\n[ "$1 $2" != "pf-wt.sh rm" ] || rm -rf "$PF_RELEASE_WT_BASE/$3"\n' "$CALLS" > "$STUBS/pf-automation-tool"
chmod +x "$GPU/pf-task-run-home" "$STUBS"/*

git init -q --bare -b main "$TMP/origin.git"
make_set() { # bead landed(1|0)
  local repo=$WT/$1/repo
  mkdir -p "$WT/$1"; git clone -q "$TMP/origin.git" "$repo" 2>/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"
  if [ "$2" = 1 ]; then git -C "$repo" push -q origin HEAD:main; else git -C "$repo" switch -q -c "$1"; fi
  printf '%s' "$repo"
}

run_case() { # bead -- env assignments...
  local bead=$1; shift
  rm -f "$CALLS/state" "$CALLS/release.json" "$CALLS/remove"
  # -u BASH_ENV: a login BASH_ENV may re-prepend ~/.local/bin and resolve the REAL tools.
  out=$(env -u BASH_ENV PATH="$STUBS:$PATH" PF_AUTOMATION_TOOL="$STUBS/pf-automation-tool" GPU14_ROOT="$GPU" PF_RELEASE_WT_BASE="$WT" PF_RELEASE_PRESERVED_BASE="$PRES" \
        CALLS="$CALLS" RUN_WORKTREE="$WT/$bead/repo" "$@" bash "$SCRIPT" pft-test "$bead" 2>&1); rc=$?
}
req() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CALLS/release.json" "$1" 2>/dev/null; }
kept_receipt() { printf '{"release_worktree":{"retention":"kept","kept_paths":[{"path":{"text":"%s"}}]}%s}' "$(realpath "$1")" "${2:-}"; }

# 1. KEEP_WORKTREE=1: retention requested for every repo path, receipt read back, nothing removed.
repo=$(make_set tsp-keep 1)
run_case tsp-keep KEEP_WORKTREE=1 STUB_RECEIPT="$(kept_receipt "$repo")"
[ "$rc" = 0 ] && grep -q 'worktrees KEPT' <<<"$out" && [ ! -e "$CALLS/remove" ] && [ -d "$repo" ] \
  && ok 'KEEP_WORKTREE releases, reads the kept receipt back and removes nothing' \
  || bad "KEEP_WORKTREE releases, reads the kept receipt back and removes nothing (rc=$rc out=$out)"
[ "$(req 'd["worktree_retention"]["paths"]')" = "['$(realpath "$repo")']" ] \
  && ok 'KEEP_WORKTREE passes worktree_retention paths' || bad "KEEP_WORKTREE passes worktree_retention paths ($(cat "$CALLS/release.json" 2>/dev/null))"

# 2. KEEP_WORKTREE=1 but the receipt does not say kept: exit 5, nothing removed.
run_case tsp-keep KEEP_WORKTREE=1 STUB_RECEIPT='{"release_worktree":{"retention":"removal_permitted","kept_paths":[]}}'
[ "$rc" = 5 ] && grep -q 'RELEASE_RECEIPT_MISMATCH.*retention=removal_permitted' <<<"$out" && [ ! -e "$CALLS/remove" ] \
  && ok 'receipt without the requested keep fails closed (exit 5)' || bad "receipt without the requested keep fails closed (rc=$rc out=$out)"

# 3. Plain release whose receipt unexpectedly kept the tree: exit 5, nothing removed.
run_case tsp-keep STUB_RECEIPT="$(kept_receipt "$repo")"
[ "$rc" = 5 ] && grep -q 'unrequested_keep' <<<"$out" && [ ! -e "$CALLS/remove" ] \
  && ok 'an unrequested kept receipt is never swept' || bad "an unrequested kept receipt is never swept (rc=$rc out=$out)"

# 4. Plain release with an ordinary receipt (or a legacy home without the field): removal proceeds.
run_case tsp-keep STUB_RECEIPT='{}'
[ "$rc" = 0 ] && grep -q 'pf-wt.sh rm tsp-keep' "$CALLS/remove" 2>/dev/null \
  && ok 'ordinary released receipt still removes via pf-wt' || bad "ordinary released receipt still removes via pf-wt (rc=$rc out=$out)"

# 4b. The run is released but the remover refuses (e.g. the removal guard): the failure propagates (exit 6), never
#     a silent success that leaves the tree behind (review on recovery#26, tsp-mc9m.41.1030.62).
make_set tsp-rmfail 1 >/dev/null
run_case tsp-rmfail STUB_RECEIPT='{}' FAKE_RM_FAIL=1
[ "$rc" = 6 ] && grep -q 'WORKTREE_REMOVE_FAILED' <<<"$out" && grep -q 'reason=ownership_unproven' <<<"$out" \
  && ok 'a refused removal after release exits 6 and says so' || bad "refused removal after release (rc=$rc out=$out)"

# 4c. Overridden root (WORKTREE_ROOT): the per-repo remove succeeds but a stray file keeps the set dir; that is a
#     surviving verified path, so exit 6, not success (review on recovery#26).
git clone -q "$TMP/origin.git" "$TMP/primary-ovr"
mkdir -p "$WT/tsp-ovr-r2"
git -C "$TMP/primary-ovr" worktree add -q -b tsp-ovr "$WT/tsp-ovr-r2/repo" origin/main 2>/dev/null
git -C "$WT/tsp-ovr-r2/repo" branch -q --set-upstream-to=origin/main 2>/dev/null
: > "$WT/tsp-ovr-r2/stray"
run_case tsp-ovr STUB_RECEIPT='{}' WORKTREE_ROOT="$WT/tsp-ovr-r2" RUN_WORKTREE="$WT/tsp-ovr-r2/repo"
[ "$rc" = 6 ] && [ ! -e "$WT/tsp-ovr-r2/repo" ] && grep -q "WORKTREE_REMOVE_FAILED path=$WT/tsp-ovr-r2 reason=set_dir_not_empty" <<<"$out" \
  && ok 'an overridden set dir left non-empty after release exits 6' || bad "overridden set dir survivor (rc=$rc out=$out)"
rm -f "$WT/tsp-ovr-r2/stray"

# 5. PRESERVATION bundle: supersede.preservation + retention requested, receipt sha256 read back.
repo=$(make_set tsp-bundle 0)
bundle=$PRES/tsp-bundle/repo.bundle; mkdir -p "$(dirname "$bundle")"
git -C "$repo" bundle create -q "$bundle" tsp-bundle ^origin/main 2>/dev/null
sha=$(sha256sum < "$bundle" | cut -d' ' -f1)
good_receipt=$(kept_receipt "$repo" ",\"release_disposition\":{\"preservation\":{\"kind\":\"bundle\",\"path\":{\"text\":\"$bundle\"},\"sha256\":{\"text\":\"$sha\"}}}")
run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="bundle:$bundle#$sha" STUB_RECEIPT="$good_receipt"
[ "$rc" = 0 ] && grep -q "bundle_sha256=$sha" <<<"$out" && [ ! -e "$CALLS/remove" ] \
  && [ "$(req 'd["supersede"]["preservation"]["sha256"]')" = "$sha" ] && [ "$(req 'd["worktree_retention"]["paths"][0]')" = "$(realpath "$repo")" ] \
  && ok 'PRESERVATION passes the bundle and keeps the tree' || bad "PRESERVATION passes the bundle and keeps the tree (rc=$rc out=$out)"

# 6. Receipt bundle sha256 differs from the request: exit 5.
run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="bundle:$bundle#$sha" \
  STUB_RECEIPT="$(kept_receipt "$repo" ',"release_disposition":{"preservation":{"sha256":{"text":"'"$(printf 0%.0s {1..64})"'"}}}')"
[ "$rc" = 5 ] && grep -q 'bundle_receipt=' <<<"$out" && ok 'receipt bundle sha256 mismatch fails closed' || bad "receipt bundle sha256 mismatch fails closed (rc=$rc out=$out)"

# 7. Local pre-checks refuse before any pf-task release call.
ln -s "$bundle" "$PRES/link.bundle"; cp "$bundle" "$TMP/outside.bundle"
# A FIFO under the root must refuse promptly, never block the pre-check on open().
mkfifo "$PRES/fifo.bundle"
run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="bundle:$PRES/fifo.bundle#$sha" STUB_RECEIPT="$good_receipt" timeout 20
[ "$rc" = 2 ] && grep -q preservation_not_regular_file <<<"$out" && [ ! -e "$CALLS/release.json" ] \
  && ok 'FIFO bundle refuses without blocking' || bad "FIFO bundle refuses without blocking (rc=$rc out=$out)"
for spec in "bundle:$bundle#$(printf 1%.0s {1..64})|preservation_sha256_mismatch" "bundle:$PRES/link.bundle#$sha|preservation_not_regular_file" \
            "bundle:$TMP/outside.bundle#$sha|preservation_outside_root" "file:$bundle|preservation_malformed"; do
  run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="${spec%|*}" STUB_RECEIPT="$good_receipt"
  [ "$rc" = 2 ] && grep -q "${spec#*|}" <<<"$out" && [ ! -e "$CALLS/release.json" ] \
    && ok "pre-check ${spec#*|} refuses before release" || bad "pre-check ${spec#*|} refuses before release (rc=$rc out=$out)"
done
# An unresolvable preserved root refuses (never widens to "any absolute path").
run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="bundle:$TMP/outside.bundle#$sha" \
  PF_RELEASE_PRESERVED_BASE="$TMP/no-such-root" STUB_RECEIPT="$good_receipt"
[ "$rc" = 2 ] && grep -q preservation_root_unresolved <<<"$out" && [ ! -e "$CALLS/release.json" ] \
  && ok 'unresolvable preserved root refuses' || bad "unresolvable preserved root refuses (rc=$rc out=$out)"
run_case tsp-bundle PRESERVATION="bundle:$bundle#$sha" STUB_RECEIPT="$good_receipt"
[ "$rc" = 2 ] && grep -q preservation_requires_superseded_by <<<"$out" && [ ! -e "$CALLS/release.json" ] \
  && ok 'PRESERVATION without SUPERSEDED_BY refuses' || bad "PRESERVATION without SUPERSEDED_BY refuses (rc=$rc out=$out)"

# 8. Existing launch-terminal supersede path: expose paired quiesce actor/reason without a new disposition.
repo=$(make_set tsp-quiesce 1)
quiesce_receipt=$(kept_receipt "$repo" ',"release_runtime":{"quiescence":{"actor":"gpu-14","reason":"retire superseded launcher-lost run"}}')
run_case tsp-quiesce KEEP_WORKTREE=1 SUPERSEDED_BY=pocketforge-os/pfvd#61 SUPERSEDE_REASON='successor work landed' \
  QUIESCE_ACTOR=gpu-14 QUIESCE_REASON='retire superseded launcher-lost run' STUB_RECEIPT="$quiesce_receipt"
[ "$rc" = 0 ] && [ "$(req 'd["quiesce"]')" = "{'actor': 'gpu-14', 'reason': 'retire superseded launcher-lost run'}" ] \
  && [ "$(req 'd.get("disposition")')" = None ] \
  && ok 'launch-terminal supersede passes quiesce without a new disposition' \
  || bad "launch-terminal quiesce request (rc=$rc out=$out req=$(cat "$CALLS/release.json" 2>/dev/null))"

# 9. Controller-lost path: explicit flag adds only the audited disposition and receipt must echo it.
controller_lost_receipt=$(kept_receipt "$repo" ',"release_runtime":{"quiescence":{"actor":"gpu-14","reason":"retire superseded controller-lost run"}},"release_disposition":{"disposition":"superseded_controller_lost","reason":"retire superseded controller-lost run","superseded_by":{"text":"pocketforge-os/pfvd#60"},"cancelled_count":2}')
run_case tsp-quiesce KEEP_WORKTREE=1 SUPERSEDED_BY=pocketforge-os/pfvd#60 SUPERSEDE_REASON='successor work landed' \
  QUIESCE_ACTOR=gpu-14 QUIESCE_REASON='retire superseded controller-lost run' SUPERSEDED_CONTROLLER_LOST=1 \
  STUB_RECEIPT="$controller_lost_receipt"
[ "$rc" = 0 ] && [ "$(req 'd["disposition"]["type"]')" = superseded_controller_lost ] \
  && [ "$(req 'd["disposition"]["reason"]')" = 'retire superseded controller-lost run' ] \
  && ok 'controller-lost flag passes the audited disposition with supersede and quiesce' \
  || bad "controller-lost disposition request (rc=$rc out=$out req=$(cat "$CALLS/release.json" 2>/dev/null))"

# 10. Inputs are paired and the controller-lost flag cannot weaken either precondition.
for spec in \
  "QUIESCE_ACTOR=gpu-14|quiesce_actor_reason_must_be_paired" \
  "QUIESCE_REASON=why|quiesce_actor_reason_must_be_paired" \
  "SUPERSEDED_CONTROLLER_LOST=2|superseded_controller_lost_not_0_or_1" \
  "SUPERSEDED_CONTROLLER_LOST=1 QUIESCE_ACTOR=gpu-14 QUIESCE_REASON=why|superseded_controller_lost_requires_superseded_by" \
  "SUPERSEDED_CONTROLLER_LOST=1 SUPERSEDED_BY=pocketforge-os/pfvd#60 SUPERSEDE_REASON=why|superseded_controller_lost_requires_quiesce"; do
  vars=${spec%|*}; why=${spec#*|}
  # The test table intentionally expands assignment words through env.
  # shellcheck disable=SC2086
  run_case tsp-quiesce $vars STUB_RECEIPT="$controller_lost_receipt"
  [ "$rc" = 2 ] && grep -q "$why" <<<"$out" && [ ! -e "$CALLS/release.json" ] \
    && ok "$why refuses before release" || bad "$why (rc=$rc out=$out)"
done

# 11. Receipt read-back covers both the quiesce attestation and disposition, never just released state.
run_case tsp-quiesce KEEP_WORKTREE=1 SUPERSEDED_BY=pocketforge-os/pfvd#60 SUPERSEDE_REASON='successor work landed' \
  QUIESCE_ACTOR=gpu-14 QUIESCE_REASON='retire superseded controller-lost run' SUPERSEDED_CONTROLLER_LOST=1 \
  STUB_RECEIPT="$(kept_receipt "$repo" ',"release_runtime":{"quiescence":{"actor":"other","reason":"wrong"}},"release_disposition":{"disposition":"superseded"}')"
[ "$rc" = 5 ] && grep -q 'RELEASE_RECEIPT_MISMATCH.*quiesce_receipt=' <<<"$out" && [ ! -e "$CALLS/remove" ] \
  && ok 'quiesce receipt mismatch keeps the tree' \
  || bad "quiesce receipt mismatch (rc=$rc out=$out)"

for receipt_case in \
  'type|,"release_runtime":{"quiescence":{"actor":"gpu-14","reason":"retire superseded controller-lost run"}},"release_disposition":{"disposition":"superseded","reason":"retire superseded controller-lost run","superseded_by":{"text":"pocketforge-os/pfvd#60"}}' \
  'reason|,"release_runtime":{"quiescence":{"actor":"gpu-14","reason":"retire superseded controller-lost run"}},"release_disposition":{"disposition":"superseded_controller_lost","reason":"wrong reason","superseded_by":{"text":"pocketforge-os/pfvd#60"}}' \
  'superseded_by|,"release_runtime":{"quiescence":{"actor":"gpu-14","reason":"retire superseded controller-lost run"}},"release_disposition":{"disposition":"superseded_controller_lost","reason":"retire superseded controller-lost run","superseded_by":{"text":"pocketforge-os/pfvd#wrong"}}'; do
  field=${receipt_case%%|*}; receipt_extra=${receipt_case#*|}
  run_case tsp-quiesce KEEP_WORKTREE=1 SUPERSEDED_BY=pocketforge-os/pfvd#60 SUPERSEDE_REASON='successor work landed' \
    QUIESCE_ACTOR=gpu-14 QUIESCE_REASON='retire superseded controller-lost run' SUPERSEDED_CONTROLLER_LOST=1 \
    STUB_RECEIPT="$(kept_receipt "$repo" "$receipt_extra")"
  [ "$rc" = 5 ] && grep -q 'RELEASE_RECEIPT_MISMATCH.*controller_lost_receipt=' <<<"$out" && [ ! -e "$CALLS/remove" ] \
    && ok "controller-lost $field receipt mismatch keeps the tree" \
    || bad "controller-lost $field receipt mismatch (rc=$rc out=$out)"
done

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
