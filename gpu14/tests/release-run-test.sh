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
printf '#!/bin/sh\necho "$*" >> "%s/remove"\n' "$CALLS" > "$STUBS/pf-automation-tool"
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
for spec in "bundle:$bundle#$(printf 1%.0s {1..64})|preservation_sha256_mismatch" "bundle:$PRES/link.bundle#$sha|preservation_not_regular_file" \
            "bundle:$TMP/outside.bundle#$sha|preservation_outside_root" "file:$bundle|preservation_malformed"; do
  run_case tsp-bundle SUPERSEDED_BY=tsp-x.1 SUPERSEDE_REASON=r PRESERVATION="${spec%|*}" STUB_RECEIPT="$good_receipt"
  [ "$rc" = 2 ] && grep -q "${spec#*|}" <<<"$out" && [ ! -e "$CALLS/release.json" ] \
    && ok "pre-check ${spec#*|} refuses before release" || bad "pre-check ${spec#*|} refuses before release (rc=$rc out=$out)"
done
run_case tsp-bundle PRESERVATION="bundle:$bundle#$sha" STUB_RECEIPT="$good_receipt"
[ "$rc" = 2 ] && grep -q preservation_requires_superseded_by <<<"$out" && [ ! -e "$CALLS/release.json" ] \
  && ok 'PRESERVATION without SUPERSEDED_BY refuses' || bad "PRESERVATION without SUPERSEDED_BY refuses (rc=$rc out=$out)"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
