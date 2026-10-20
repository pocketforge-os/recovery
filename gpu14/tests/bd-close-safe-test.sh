#!/usr/bin/env bash
# bd-close-safe.sh legacy output + typed --keep-for-run close (tsp-mc9m.41.995.130.3).
# Hermetic: temp gpu14 root (admission/run pairs), stub pf-task-run-home + pf-task, a fake bd that records argv/cwd/stdin,
# temp git repos (shared-checkout root) and a temp wt root. Never touches a live home, the journal, real bd or real wt.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT=${BD_CLOSE_SAFE_SCRIPT:-$HERE/bd-close-safe.sh}
# Safety: a script without the root overrides would read the LIVE gpu14 dir and wt root. Refuse to exercise it.
grep -q 'GPU14_ROOT' "$SCRIPT" || { echo "FAIL  $SCRIPT has no GPU14_ROOT override; refusing to run it non-hermetically"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

STUBS=$TMP/stubs; GPU=$TMP/gpu14; WT=$TMP/wt; SRC=$TMP/src; MC=$TMP/mc; CALLS=$TMP/calls; STATES=$TMP/states
mkdir -p "$STUBS" "$GPU" "$WT" "$SRC" "$MC" "$CALLS" "$STATES"
cat > "$GPU/pf-task-run-home" <<EOF
#!/bin/sh
# args: resolve <run> --format shell
[ -e "$STATES/\$2.unresolved" ] && { echo "refused run=\$2" >&2; exit 1; }
printf 'PFT=%s; H=%s\n' "$STUBS/pf-task" "$TMP/home"
EOF
cat > "$STUBS/pf-task" <<EOF
#!/usr/bin/env bash
# args: --home H --role coordinator run.status <json>
[ "\$5" = run.status ] || { echo "unexpected op \$5" >&2; exit 9; }
run=\$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["run_id"])' "\$6")
[ -e "$STATES/\$run" ] || exit 7
printf '{"state":"%s","run_id":"%s"}\n' "\$(cat "$STATES/\$run")" "\$run"
EOF
cat > "$STUBS/bd" <<EOF
#!/usr/bin/env bash
n=\$(ls "$CALLS" | grep -c '^bd\.[0-9]*$')
{ printf 'cwd=%s\n' "\$PWD"; printf '%s\n' "\$@"; } > "$CALLS/bd.\$n"
if [ "\$1" = comment ]; then
  cat > "$CALLS/bd.\$n.stdin"
  [ -n "\${FAKE_BD_COMMENT_FAIL:-}" ] && { echo "fake bd: comment failed" >&2; exit 1; }
fi
echo "fake bd \$1 ok"
EOF
chmod +x "$GPU/pf-task-run-home" "$STUBS"/*

# Shared-checkout root: src (landed + unlanded commits), nofetch (origin unreachable).
git init -q -b main "$TMP/seed"; git -C "$TMP/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git clone -q --bare "$TMP/seed" "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$SRC/src"
git -C "$SRC/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m landed; git -C "$SRC/src" push -q origin HEAD:main
LANDED=$(git -C "$SRC/src" rev-parse HEAD)
git -C "$SRC/src" switch -q -c side; git -C "$SRC/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unlanded
UNLANDED=$(git -C "$SRC/src" rev-parse HEAD); git -C "$SRC/src" switch -q main
git clone -q "$TMP/origin.git" "$SRC/nofetch"; git -C "$SRC/nofetch" remote set-url origin "$TMP/no-such-origin.git"

admit() { # name run_id task worktree state
  printf '{"run_id":"%s"}\n' "$2" > "$GPU/admission-$1.json"
  printf '{"task":"%s","worktree":"%s"}\n' "$3" "$4" > "$GPU/run-$1.json"
  mkdir -p "$4"; [ "$5" = - ] || printf '%s' "$5" > "$STATES/$2"
}
run_case() { # args...
  rm -f "$CALLS"/bd.*
  # -u BASH_ENV: a login BASH_ENV may re-prepend ~/.local/bin and resolve the REAL bd.
  out=$(cd "$TMP" && env -u BASH_ENV -u BD_CLOSE_FOREIGN_OK PATH="$STUBS:$PATH" GPU14_ROOT="$GPU" BD_CLOSE_SAFE_WT_ROOT="$WT" \
        BD_CLOSE_SAFE_SRC_ROOT="$SRC" BD_CLOSE_SAFE_MC="$MC" ${CASE_ENV:-} bash "$SCRIPT" "$@" 2>&1); rc=$?
}
nbd() { ls "$CALLS" | grep -c '^bd\.[0-9]*$'; }
bdargs() { tr '\n' ' ' < "$CALLS/bd.$1" | sed 's/ $//'; }
expect() { # name expected_rc expected_out
  [ "$rc" = "$2" ] && [ "$out" = "$3" ] && ok "$1" || bad "$1 (rc=$rc want $2)"$'\n'"--- got:"$'\n'"$out"$'\n'"--- want:"$'\n'"$3"
}

RA=pft-aaaaaaaaaaaaaaaaaaaaaaaa; RB=pft-bbbbbbbbbbbbbbbbbbbbbbbb; RK=pft-cccccccccccccccccccccccc; RJ=pft-dddddddddddddddddddddddd
RU=pft-eeeeeeeeeeeeeeeeeeeeeeee
admit a $RA tsp-a "$WT/tsp-a/repo" released
admit b $RB tsp-b "$WT/tsp-b/repo" awaiting_release
admit k $RK tsp-k "$WT/tsp-k/repo" awaiting_release
admit k2 $RK tsp-k2 "$WT/tsp-k2/repo" awaiting_release
admit j $RJ tsp-k2 "$WT/tsp-k2-other/repo" interruption_unknown
admit u $RU tsp-u "$WT/tsp-u/repo" -; touch "$STATES/$RU.unresolved"
mkdir -p "$WT/tsp-f/repo"   # tsp-f: a set with no gpu-14 admission

echo '-- legacy (no --keep-for-run): output byte-for-byte as before'
run_case --check tsp-a
expect 'released run: --check OK' 0 "BD_CLOSE_SAFE run=$RA state=released task=tsp-a worktree=$WT/tsp-a/repo
BD_CLOSE_SAFE_CHECK_OK bead=tsp-a"
run_case tsp-a done here
expect 'released run: closes' 0 "BD_CLOSE_SAFE run=$RA state=released task=tsp-a worktree=$WT/tsp-a/repo
fake bd close ok"
[ "$(nbd)" = 1 ] && [ "$(bdargs 0)" = "cwd=$MC close tsp-a --reason done here" ] \
  && ok 'released run: plain bd close from the MC dir, no --keep-worktree' || bad "released run: plain bd close ($(bdargs 0 2>/dev/null))"
run_case tsp-b reason
expect 'unreleased run refuses' 3 "BD_CLOSE_SAFE run=$RB state=awaiting_release task=tsp-b worktree=$WT/tsp-b/repo
BD_CLOSE_SAFE_REFUSED reason=unreleased_run_owns_bead_worktree bead=tsp-b count=1 hint=release each run with release-run.sh (read rc) first"
[ "$(nbd)" = 0 ] && ok 'unreleased run: no bd call' || bad 'unreleased run: no bd call'
run_case --check tsp-f
expect 'unmapped set refuses' 3 "BD_CLOSE_SAFE_REFUSED reason=unmapped_worktree_set bead=tsp-f set=$WT/tsp-f hint=ask the owning coordinator to release it or confirm; rerun with BD_CLOSE_FOREIGN_OK='<who confirmed>'
BD_CLOSE_SAFE_REFUSED reason=unreleased_run_owns_bead_worktree bead=tsp-f count=1 hint=release each run with release-run.sh (read rc) first"
CASE_ENV="BD_CLOSE_FOREIGN_OK=coord-x" run_case --check tsp-f
expect 'unmapped set with BD_CLOSE_FOREIGN_OK passes' 0 "BD_CLOSE_SAFE foreign_set_ok='coord-x' set=$WT/tsp-f
BD_CLOSE_SAFE_CHECK_OK bead=tsp-f"
run_case --check tsp-u
expect 'unresolved run refuses' 3 "refused run=$RU
BD_CLOSE_SAFE run=$RU state=unresolved task=tsp-u worktree=$WT/tsp-u/repo
BD_CLOSE_SAFE_REFUSED reason=unreleased_run_owns_bead_worktree bead=tsp-u count=1 hint=release each run with release-run.sh (read rc) first"
run_case tsp-a
expect 'missing reason refuses' 2 "BD_CLOSE_SAFE_REFUSED reason=missing_close_reason"

echo '-- typed --keep-for-run'
WIM="work_in_main=pocketforge-os/src@$LANDED"
GOOD="acceptance met; unreleased_run=$RK $WIM release_tracked_by=tsp-rel"
run_case --check --keep-for-run $RK tsp-k $GOOD
[ "$rc" = 0 ] && grep -q "^BD_CLOSE_SAFE kept_for_run=$RK state=awaiting_release worktree=$WT/tsp-k/repo$" <<<"$out" \
  && grep -q "^BD_CLOSE_SAFE_CHECK_OK bead=tsp-k keep_worktree=1 kept=$RK release_tracked_by=tsp-rel$" <<<"$out" \
  && ok '--check: kept run passes and reports the typed close' || bad "--check: kept run passes (rc=$rc out=$out)"
[ "$(nbd)" = 0 ] && ok '--check: no bd close and no bd comment' || bad "--check: no bd calls ($(nbd) made)"
grep -q "^BD_CLOSE_SAFE_CHECK would_comment release_bead=tsp-rel line='typed_close bead=tsp-k unreleased_run=$RK worktree=$WT/tsp-k/repo $WIM'$" <<<"$out" \
  && ok '--check: names the tracking comment it would write' || bad "--check: would_comment line (out=$out)"

run_case --keep-for-run $RK tsp-k $GOOD
[ "$rc" = 0 ] && grep -q "^BD_CLOSE_SAFE_TYPED_CLOSED bead=tsp-k kept=$RK release_tracked_by=tsp-rel$" <<<"$out" \
  && ok 'kept run closes' || bad "kept run closes (rc=$rc out=$out)"
[ "$(nbd)" = 2 ] && [ "$(bdargs 0)" = "cwd=$MC close tsp-k --keep-worktree --reason $GOOD" ] \
  && ok 'success passes --keep-worktree and the full reason' || bad "success passes --keep-worktree ($(bdargs 0 2>/dev/null))"
[ "$(bdargs 1)" = "cwd=$MC comment tsp-rel --stdin" ] \
  && [ "$(cat "$CALLS/bd.1.stdin")" = "typed_close bead=tsp-k unreleased_run=$RK worktree=$WT/tsp-k/repo $WIM" ] \
  && ok 'success writes the tracking comment on release_tracked_by' || bad "tracking comment ($(bdargs 1 2>/dev/null) / $(cat "$CALLS/bd.1.stdin" 2>/dev/null))"
[ -d "$WT/tsp-k/repo" ] && ok 'kept worktree is left in place' || bad 'kept worktree is left in place'

CASE_ENV=FAKE_BD_COMMENT_FAIL=1 run_case --keep-for-run $RK tsp-k $GOOD
[ "$rc" = 4 ] && grep -q "^BD_CLOSE_SAFE_TRACK_FAILED bead=tsp-k release_bead=tsp-rel append='typed_close bead=tsp-k unreleased_run=$RK worktree=$WT/tsp-k/repo $WIM'" <<<"$out" \
  && [ "$(nbd)" = 2 ] && ok 'comment failure after close is loud (exit 4, names the line to append)' || bad "comment failure (rc=$rc out=$out)"

run_case --keep-for-run $RK tsp-k2 "unreleased_run=$RK $WIM release_tracked_by=tsp-rel"
[ "$rc" = 3 ] && grep -q "^BD_CLOSE_SAFE run=$RJ state=interruption_unknown" <<<"$out" \
  && grep -q "reason=unreleased_run_owns_bead_worktree bead=tsp-k2 count=1" <<<"$out" && [ "$(nbd)" = 0 ] \
  && ok 'an unnamed unreleased run still refuses' || bad "unnamed unreleased run (rc=$rc out=$out)"

mkdir -p "$WT/tsp-k-extra/repo"
run_case --keep-for-run $RK tsp-k $GOOD
[ "$rc" = 3 ] && grep -q "reason=unmapped_worktree_set bead=tsp-k set=$WT/tsp-k-extra" <<<"$out" && [ "$(nbd)" = 0 ] \
  && ok 'an unmapped set still refuses' || bad "unmapped set with keep (rc=$rc out=$out)"
rm -rf "$WT/tsp-k-extra"

run_case --keep-for-run $RU tsp-u "unreleased_run=$RU $WIM release_tracked_by=tsp-rel"
[ "$rc" = 3 ] && grep -q "state=unresolved" <<<"$out" && [ "$(nbd)" = 0 ] && ok 'a named but unresolved run still refuses' || bad "named unresolved (rc=$rc out=$out)"
mv "$STATES/$RK" "$STATES/$RK.off"
run_case --keep-for-run $RK tsp-k $GOOD
[ "$rc" = 3 ] && grep -q "state=unknown" <<<"$out" && [ "$(nbd)" = 0 ] && ok 'a named run with unreadable status still refuses' || bad "named unknown (rc=$rc out=$out)"
mv "$STATES/$RK.off" "$STATES/$RK"
run_case --keep-for-run $RJ tsp-k $GOOD
[ "$rc" = 3 ] && grep -q "reason=keep_for_run_not_candidate bead=tsp-k run=$RJ" <<<"$out" && [ "$(nbd)" = 0 ] \
  && ok 'a --keep-for-run that owns nothing of the bead refuses' || bad "not-candidate keep (rc=$rc out=$out)"

for spec in "missing unreleased_run=|$WIM release_tracked_by=tsp-rel|missing=unreleased_run=$RK" \
            "missing release_tracked_by=|unreleased_run=$RK $WIM|missing=release_tracked_by" \
            "missing work_in_main=|unreleased_run=$RK release_tracked_by=tsp-rel|missing=work_in_main" \
            "short work_in_main sha|unreleased_run=$RK work_in_main=src@${LANDED:0:12} release_tracked_by=tsp-rel|malformed=work_in_main=src@${LANDED:0:12}"; do
  IFS='|' read -r name reason detail <<<"$spec"
  for mode in --check close; do
    if [ "$mode" = --check ]; then run_case --check --keep-for-run $RK tsp-k $reason; else run_case --keep-for-run $RK tsp-k $reason; fi
    [ "$rc" = 2 ] && grep -q "^BD_CLOSE_SAFE_REFUSED reason=typed_close_reason_incomplete bead=tsp-k .*$detail" <<<"$out" && [ "$(nbd)" = 0 ] \
      && ok "$name refuses ($mode)" || bad "$name refuses ($mode) (rc=$rc out=$out)"
  done
done
run_case --keep-for-run $RK tsp-k
[ "$rc" = 2 ] && grep -q 'reason=typed_close_reason_incomplete' <<<"$out" && [ "$(nbd)" = 0 ] && ok 'kept run with no reason at all refuses' || bad "no reason (rc=$rc out=$out)"

for spec in "non-ancestor sha|work_in_main=src@$UNLANDED|not_ancestor" \
            "fetch failure|work_in_main=nofetch@$LANDED|fetch_failed" \
            "missing repo dir|work_in_main=pocketforge-os/absent@$LANDED|repo_missing" \
            "one bad of two|$WIM work_in_main=src@$UNLANDED|not_ancestor"; do
  IFS='|' read -r name wim detail <<<"$spec"
  run_case --keep-for-run $RK tsp-k "unreleased_run=$RK $wim release_tracked_by=tsp-rel"
  [ "$rc" = 3 ] && grep -q "^BD_CLOSE_SAFE_REFUSED reason=work_not_in_main bead=tsp-k .*detail=$detail" <<<"$out" && [ "$(nbd)" = 0 ] \
    && ok "$name refuses" || bad "$name refuses (rc=$rc out=$out)"
done

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
