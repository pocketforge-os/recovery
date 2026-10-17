#!/usr/bin/env bash
# proc-coord 2026-10-17 (tsp-mc9m.41.1030): hermetic tests for gpu14/merge-ready.sh. gh, gpu14-merge.sh and lane-msg.sh
# are faked in a private temp root; nothing reads GitHub, merges, or messages a lane.
# usage: merge-ready-test.sh      rc 0 all pass
set -uo pipefail
MR=${MR_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/merge-ready.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/mr-tests.XXXXXX"); trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
H=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
# gh pr view N -R repo --json fields [--jq expr]
n=$3; jqe=""; [ "${8:-}" = --jq ] && jqe=$9
[ "$n" = "${FAKE_GH_FAIL_N:-}" ] && exit 1
st=$(cat "$FAKE_DIR/state-$n" 2>/dev/null || echo OPEN)
# FAKE_HEAD2: the head reported from the 2nd read on (a push between the first check and the merge).
c=$(( $(cat "$FAKE_DIR/reads-$n" 2>/dev/null || echo 0) + 1 )); echo $c > "$FAKE_DIR/reads-$n"
[ -n "${FAKE_HEAD2:-}" ] && [ $c -ge 2 ] && FAKE_HEAD=$FAKE_HEAD2
[ "$st" = MERGED ] && [ -n "${FAKE_MERGED_HEAD:-}" ] && FAKE_HEAD=$FAKE_MERGED_HEAD
fj=$(printf '%s\n' ${FAKE_FILES:-scripts/foo.sh} | jq -R '{path:.}' | jq -s .)
j=$(jq -n --arg h "$FAKE_HEAD" --arg s "$st" --argjson f "$fj" --arg b "${FAKE_BODY:-}" \
  '{headRefOid:$h,state:$s,isDraft:false,title:"t",body:$b,files:$f,mergeCommit:{oid:"m3rge"}}')
if [ -n "$jqe" ]; then jq -r "$jqe" <<<"$j"; else echo "$j"; fi
SH
cat > "$T/bin/merge" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_MERGE_RC:-0}" -eq 0 ] || { echo "REFUSED reason=fake"; exit "$FAKE_MERGE_RC"; }
echo "$*" >> "$FAKE_DIR/merge-args"; echo "merged $1"; echo MERGED > "$FAKE_DIR/state-${1##*#}"
SH
cat > "$T/bin/send" <<'SH'
#!/usr/bin/env bash
cp "$2" "$FAKE_DIR/sent-$3.txt"; echo '{"delivery": "queued"}'; exit "${FAKE_SEND_RC:-0}"
SH
chmod +x "$T/bin/"*

setup() {  # fresh sandbox in $S with one queued bead for lane fam
  S=$T/s$((++N)); mkdir -p "$S/root/fleet-board/lane-queue" "$S/win"
  export GPU14_ROOT=$S/root MR_GH=$T/bin/gh MR_MERGE=$T/bin/merge MR_SEND=$T/bin/send MR_WINDOWS=$S/win FAKE_DIR=$S FAKE_HEAD=$H
  unset FAKE_FILES FAKE_BODY FAKE_MERGE_RC FAKE_SEND_RC MERGE_READY_AUTO FAKE_GH_FAIL_N FAKE_HEAD2 FAKE_MERGED_HEAD
  printf '# queue\ntsp-next.1 do the thing\n' > "$S/root/fleet-board/lane-queue/fam.txt"
}
mr() { out=$("$MR" run1 TOKX fam "$1" 2>&1); rc=$?; }
qlines() { grep -cvE '^[[:space:]]*(#|$)' "$S/root/fleet-board/lane-queue/fam.txt"; }
cprows() { [ -f "$S/root/fleet-board/close-pending.tsv" ] && wc -l < "$S/root/fleet-board/close-pending.tsv" || echo 0; }
L="TOKX state=HANDBACK reason=MERGE_READY pr=o/r#5 head=$H bead=tsp-old.2 acceptance=met"

setup; mr "TOKX state=HANDBACK reason=MERGE_READY"
[ $rc -eq 10 ] && grep -q 'reason=unparsed_status_line' <<<"$out" && ok unparsed_holds || no unparsed_holds "$rc $out"

setup; MERGE_READY_AUTO=0 mr "$L"
[ $rc -eq 10 ] && grep -q auto_disabled <<<"$out" && ok kill_switch_holds || no kill_switch_holds "$rc $out"

setup; touch "$S/root/merge-ready.pause"; mr "$L"
[ $rc -eq 10 ] && grep -q paused_by_file <<<"$out" && ok pause_file_holds || no pause_file_holds "$rc $out"

setup; mr "$L paired=o/r#6"
[ $rc -eq 10 ] && grep -q lane_declared_paired <<<"$out" && ok paired_holds || no paired_holds "$rc $out"

setup; FAKE_HEAD=fedcba9876543210fedcba9876543210fedcba98 mr "$L"
[ $rc -eq 10 ] && grep -q head_moved <<<"$out" && ok head_moved_holds || no head_moved_holds "$rc $out"

setup; echo MERGED > "$S/state-5"; mr "$L"
[ $rc -eq 10 ] && grep -q pr_not_open_MERGED <<<"$out" && ok not_open_holds || no not_open_holds "$rc $out"

setup; export FAKE_FILES=.github/workflows/ci.yml; mr "$L"
[ $rc -eq 10 ] && grep -q gate_change_needs_producer_run <<<"$out" && ok gate_needs_producer_run || no gate_needs_producer_run "$rc $out"
mr "$L producer_run=$H bead_complete=yes"
[ $rc -eq 0 ] && ok gate_with_producer_run_merges || no gate_with_producer_run_merges "$rc $out"

setup; printf 'o/r:scripts/foo\\.sh\tfoo_owner\n' > "$S/root/merge-ready-holds.tsv"; mr "$L"
[ $rc -eq 10 ] && grep -q rule_foo_owner <<<"$out" && ok holds_tsv_rule || no holds_tsv_rule "$rc $out"

setup; echo OPEN > "$S/state-6"; export FAKE_BODY="Related https://github.com/o/r/pull/6"; mr "$L"
[ $rc -eq 10 ] && grep -q 'related_pr_open o/r#6' <<<"$out" && ok related_open_holds || no related_open_holds "$rc $out"

setup; export FAKE_FILES=scripts/pf-kit-window-run; mkdir -p "$S/win/g1"; echo '{"State":"open"}' > "$S/win/g1/runner.json"
out=$("$MR" run1 TOKX fam "TOKX state=HANDBACK reason=MERGE_READY pr=pocketforge-os/pocketforge-automation#5 head=$H bead=b.1" 2>&1); rc=$?
[ $rc -eq 10 ] && grep -q 'deploy_surface_while_window_not_closed gen=g1 state=open' <<<"$out" && ok deploy_surface_window_holds || no deploy_surface_window_holds "$rc $out"

setup; export FAKE_BODY="Related https://github.com/o/r/pull/7" FAKE_GH_FAIL_N=7; mr "$L"
[ $rc -eq 10 ] && grep -q 'related_pr_unreadable o/r#7' <<<"$out" && ok related_unreadable_holds || no related_unreadable_holds "$rc $out"

setup; export FAKE_FILES=scripts/pf-kit-window-run; mkdir -p "$S/win/g2"; echo 'not json' > "$S/win/g2/runner.json"
out=$("$MR" run1 TOKX fam "TOKX state=HANDBACK reason=MERGE_READY pr=pocketforge-os/pocketforge-automation#5 head=$H bead=b.1" 2>&1); rc=$?
[ $rc -eq 10 ] && grep -q 'window_state_unreadable gen=g2' <<<"$out" && ok malformed_window_state_holds || no malformed_window_state_holds "$rc $out"
for wst in revoked failed; do
  setup; export FAKE_FILES=scripts/pf-kit-window-run; mkdir -p "$S/win/g3"; echo "{\"State\":\"$wst\"}" > "$S/win/g3/runner.json"
  out=$("$MR" run1 TOKX fam "TOKX state=HANDBACK reason=MERGE_READY pr=pocketforge-os/pocketforge-automation#5 head=$H bead=b.1" 2>&1); rc=$?
  [ $rc -eq 10 ] && grep -q "window_not_closed gen=g3 state=$wst" <<<"$out" && ok "unknown_window_state_holds_$wst" || no "unknown_window_state_holds_$wst" "$rc $out"
done
setup; export FAKE_FILES=scripts/pf-kit-window-run; mkdir -p "$S/win/g4"; echo '{"State":"closed"}' > "$S/win/g4/runner.json"
out=$("$MR" run1 TOKX fam "TOKX state=HANDBACK reason=MERGE_READY pr=pocketforge-os/pocketforge-automation#5 head=$H bead=b.1 bead_complete=yes" 2>&1); rc=$?
[ $rc -eq 0 ] && ok closed_window_allows_deploy_surface || no closed_window_allows_deploy_surface "$rc $out"

setup; export FAKE_HEAD2=fedcba9876543210fedcba9876543210fedcba98; mr "$L bead_complete=yes"
[ $rc -eq 10 ] && grep -q head_moved_pre_merge <<<"$out" && [ ! -f "$S/state-5" ] && [ "$(qlines)" = 1 ] && ok head_moved_before_merge_holds || no head_moved_before_merge_holds "$rc $out"

setup; export FAKE_MERGED_HEAD=fedcba9876543210fedcba9876543210fedcba98; mr "$L bead_complete=yes"
[ $rc -eq 10 ] && grep -q merged_head_differs <<<"$out" && [ "$(qlines)" = 1 ] && [ "$(cprows)" = 0 ] && ok merged_head_differs_holds || no merged_head_differs_holds "$rc $out"

setup; export FAKE_MERGE_RC=3; mr "$L bead_complete=yes"
[ $rc -eq 10 ] && grep -q merge_refused <<<"$out" && [ "$(qlines)" = 1 ] && ok merge_refused_holds || no merge_refused_holds "$rc $out"

# Multi-PR bead (tfar): without bead_complete=yes the lane continues; queue and close-pending untouched.
setup; mr "$L"
[ $rc -eq 0 ] && grep -q next=continue_current_bead <<<"$out" && [ "$(qlines)" = 1 ] && [ "$(cprows)" = 0 ] \
  && grep -q 'Continue your CURRENT bead (tsp-old.2)' "$S"/sent-mr-cont-*.txt && ok absent_complete_continues || no absent_complete_continues "$rc $out"
setup; mr "$L bead_complete=no"
[ $rc -eq 0 ] && grep -q next=continue_current_bead <<<"$out" && [ "$(qlines)" = 1 ] && [ "$(cprows)" = 0 ] && ok no_complete_continues || no no_complete_continues "$rc $out"
setup; export FAKE_SEND_RC=1; mr "$L"
[ $rc -eq 11 ] && grep -q continue_send_failed <<<"$out" && ok continue_send_failure_rc11 || no continue_send_failure_rc11 "$rc $out"

setup; mr "$L bead_complete=yes"
[ $rc -eq 0 ] && grep -q 'next=tsp-next.1' <<<"$out" && [ "$(qlines)" = 0 ] && [ "$(cprows)" = 1 ] \
  && grep -q 'NEXT ASSIGNMENT: bead tsp-next.1 (do the thing)' "$S/sent-mr-next-tsp-next.1.txt" \
  && grep -q 'Do NOT run bd close' "$S/sent-mr-next-tsp-next.1.txt" \
  && grep -qP '^tsp-old\.2\trun1\to/r#5\tm3rge\tmet\t' "$S/root/fleet-board/close-pending.tsv" && ok complete_pops_next || no complete_pops_next "$rc $out"
grep -qx "o/r#5 --expect-head $H" "$S/merge-args" && ok merge_passes_expect_head || no merge_passes_expect_head "$(cat "$S/merge-args" 2>&1)"

setup; printf '# q\n\tBAD id\n' > "$S/root/fleet-board/lane-queue/fam.txt"; mr "$L bead_complete=yes"
[ $rc -eq 11 ] && grep -q bad_queue_line <<<"$out" && grep -q BAD "$S/root/fleet-board/lane-queue/fam.txt" && ok bad_queue_line_rc11 || no bad_queue_line_rc11 "$rc $out"

setup; : > "$S/root/fleet-board/lane-queue/fam.txt"; mr "$L bead_complete=yes"
[ $rc -eq 11 ] && grep -q MERGE_READY_MERGED_NO_NEXT <<<"$out" && [ "$(cprows)" = 1 ] && ok empty_queue_rc11 || no empty_queue_rc11 "$rc $out"

setup; export FAKE_SEND_RC=1; mr "$L bead_complete=yes"
[ $rc -eq 11 ] && grep -q send_failed_for=tsp-next.1 <<<"$out" && [ "$(qlines)" = 1 ] && ok next_send_failure_requeues || no next_send_failure_requeues "$rc $out"

echo "merge-ready-test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
