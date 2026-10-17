#!/usr/bin/env bash
# proc-coord 2026-10-17 (recovery#13 review): hermetic tests for gpu14/assign-next.sh (delivery failure never loses a
# bead) and gpu14/batch-release.sh (release only after evidence is preserved; tracked dirt or any failure skips).
# lane-msg.sh and release-run.sh are faked; worktrees are throwaway git repos in a private temp root.
# usage: assign-release-test.sh      rc 0 all pass
set -uo pipefail
BIN=${AR_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
T=$(mktemp -d "${TMPDIR:-/tmp}/ar-tests.XXXXXX"); trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
mkdir -p "$T/bin"
printf '#!/bin/sh\ncp "$2" "$FAKE_S/sent-$3.txt"; exit ${FAKE_SEND_RC:-0}\n' > "$T/bin/send"
printf '#!/bin/sh\necho "$1 $2" >> "$FAKE_S/released"; echo RELEASED\n' > "$T/bin/release"
chmod +x "$T/bin/"*
setup() {
  S=$T/s$((++N)); mkdir -p "$S/root/fleet-board/lane-queue" "$S/wt" "$S/pres"
  export GPU14_ROOT=$S/root AN_SEND=$T/bin/send BR_RELEASE=$T/bin/release BR_WT_ROOT=$S/wt BR_PRESERVE_ROOT=$S/pres FAKE_S=$S
  unset FAKE_SEND_RC
}
mkwt() {  # mkwt <wid> <repo>: a pushed clone (HEAD on a remote branch) in $S/wt/<wid>/<repo>
  git init -q --bare "$S/remote-$2.git"; git clone -q "$S/remote-$2.git" "$S/wt/$1/$2" 2>/dev/null
  W=$S/wt/$1/$2; git -C "$W" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'tracked\n' > "$W/a.txt"; printf 'target/\n' > "$W/.gitignore"; git -C "$W" add a.txt .gitignore
  git -C "$W" -c user.email=t@t -c user.name=t commit -q -m files; git -C "$W" push -q origin HEAD:main 2>/dev/null; git -C "$W" fetch -q
}

# ---- assign-next
setup; printf '# q\ntsp-a.1 first\ntsp-a.2 second\n' > "$S/root/fleet-board/lane-queue/fam.txt"
out=$("$BIN/assign-next.sh" fam run1 TOK 2>&1); rc=$?
[ $rc -eq 0 ] && grep -q 'ASSIGNED lane=fam run=run1 next=tsp-a.1' <<<"$out" && ! grep -q tsp-a.1 "$S/root/fleet-board/lane-queue/fam.txt" \
  && grep -q 'NEXT ASSIGNMENT: tsp-a.1 first' "$S/sent-assign-tsp-a.1.txt" && ok assign_pops_and_sends || no assign_pops_and_sends "$rc $out"
setup; printf 'tsp-a.1 first\ntsp-a.2 second\n' > "$S/root/fleet-board/lane-queue/fam.txt"; export FAKE_SEND_RC=1
out=$("$BIN/assign-next.sh" fam run1 TOK 2>&1); rc=$?
[ $rc -eq 12 ] && grep -q ASSIGN_SEND_FAILED <<<"$out" && [ "$(head -1 "$S/root/fleet-board/lane-queue/fam.txt")" = "tsp-a.1 first" ] \
  && [ "$(grep -c . "$S/root/fleet-board/lane-queue/fam.txt")" = 2 ] && [ ! -f "$S/root/fleet-board/lane-queue/fam.done" ] && ok assign_send_failure_restores || no assign_send_failure_restores "$rc $out"
setup; : > "$S/root/fleet-board/lane-queue/fam.txt"; out=$("$BIN/assign-next.sh" fam run1 TOK 2>&1); rc=$?
[ $rc -eq 11 ] && grep -q ASSIGN_EMPTY <<<"$out" && ok assign_empty_rc11 || no assign_empty_rc11 "$rc $out"

# ---- batch-release
setup; mkwt b.1 repo; mkdir -p "$W/target" "$W/ev dir"; echo big > "$W/target/x"; printf 'proof\n' > "$W/ev dir/receipt one.txt"
out=$("$BIN/batch-release.sh" run1:b.1 2>&1)
grep -q 'RELEASE run=run1 bead=b.1 rc=0' <<<"$out" && [ -f "$S/pres/b.1/preserved-run1/repo/ev dir/receipt one.txt" ] && [ ! -e "$S/pres/b.1/preserved-run1/repo/target" ] \
  && grep -q 'receipt one.txt' "$S/pres/b.1/preserved-run1/repo.SHA256SUMS" && ok release_preserves_untracked_then_releases || no release_preserves_untracked_then_releases "$out"
setup; mkwt b.2 repo; echo changed >> "$W/a.txt"
out=$("$BIN/batch-release.sh" run1:b.2 2>&1)
grep -q 'SKIP run=run1 bead=b.2 reason=tracked_changes:1' <<<"$out" && [ ! -f "$S/released" ] && ok tracked_modification_skips || no tracked_modification_skips "$out"
setup; mkwt b.3 repo; git -C "$W" rm -q a.txt
out=$("$BIN/batch-release.sh" run1:b.3 2>&1)
grep -q 'reason=tracked_changes' <<<"$out" && [ ! -f "$S/released" ] && ok tracked_deletion_skips || no tracked_deletion_skips "$out"
setup; mkwt b.4 repo; echo x > "$W/new.txt"; mkdir -p "$S/pres/b.4/preserved-run1"; chmod 500 "$S/pres/b.4/preserved-run1"
out=$("$BIN/batch-release.sh" run1:b.4 2>&1); chmod 700 "$S/pres/b.4/preserved-run1"
grep -q 'reason=preserve_copy_failed' <<<"$out" && [ ! -f "$S/released" ] && ok copy_failure_skips || no copy_failure_skips "$out"
setup; mkwt b.5 repo; echo 'gitdir: /nonexistent' > "$S/wt/b.5/repo/.git.tmp"; rm -rf "$W/.git"; mv "$S/wt/b.5/repo/.git.tmp" "$W/.git"
out=$("$BIN/batch-release.sh" run1:b.5 2>&1)
grep -qE 'reason=(unpushed_head|git_status_failed)' <<<"$out" && [ ! -f "$S/released" ] && ok unreadable_repo_skips || no unreadable_repo_skips "$out"

echo "assign-release-test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
